import Foundation
import os.log

private let llmLogger = Logger(subsystem: "com.vocalflow.app", category: "llm")

enum LLMProvider: String, CaseIterable, Identifiable {
    case groq        = "groq"
    case openRouter  = "open_router"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq:       return "Groq"
        case .openRouter: return "OpenRouter"
        }
    }

    var baseURL: URL {
        switch self {
        case .groq:       return URL(staticString: "https://api.groq.com/openai/v1")
        case .openRouter: return URL(staticString: "https://openrouter.ai/api/v1")
        }
    }

    var modelsURL: URL          { baseURL.appendingPathComponent("models") }
    var chatCompletionsURL: URL { baseURL.appendingPathComponent("chat/completions") }

    var signupURL: URL {
        switch self {
        case .groq:       return URL(staticString: "https://console.groq.com/keys")
        case .openRouter: return URL(staticString: "https://openrouter.ai/keys")
        }
    }

    var keychainKey: String {
        switch self {
        case .groq:       return "groq_api_key"
        case .openRouter: return "openrouter_api_key"
        }
    }
}

struct LLMModel: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct LLMProcessingOptions {
    var codeMix: String?        // nil = disabled; value = mixType e.g. "Hinglish"
    var fixSpelling: Bool
    var fixGrammar: Bool
    var targetLanguage: String? // nil = disabled; value = e.g. "French"
    var customPrompt: String?   // nil/empty = disabled; user-supplied bias prepended to system prompt

    var hasAnyStep: Bool {
        if codeMix != nil || fixSpelling || fixGrammar || targetLanguage != nil { return true }
        let trimmed = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }
}

class LLMService {
    /// Per-request timeout for chat completions. Default URLSession is 60s, but some
    /// OpenRouter models (Anthropic Sonnet, large Gemini) routinely take 30+ seconds —
    /// 90s leaves headroom without hanging the UI forever.
    var requestTimeout: TimeInterval = 90

    /// Delay before the single retry on 429/5xx / network blips.
    var retryDelay: TimeInterval = 0.25

    func fetchModels(provider: LLMProvider, apiKey: String) async throws -> [LLMModel] {
        guard !apiKey.isEmpty else { throw APIError.missingKey }

        var request = URLRequest(url: provider.modelsURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performRequest(request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(httpStatus) else {
            let body = String(data: data, encoding: .utf8)
            llmLogger.error("\(provider.displayName) /models HTTP \(httpStatus): \(body ?? "<binary>")")
            throw APIError.http(status: httpStatus, body: body)
        }
        guard let root = try? JSONDecoder().decode(LLMModelsResponse.self, from: data) else {
            let body = String(data: data, encoding: .utf8)
            llmLogger.error("\(provider.displayName) /models decode failed: \(body ?? "<binary>")")
            throw APIError.decoding
        }
        let models = (root.data ?? [])
            .map { LLMModel(id: $0.id, displayName: $0.name ?? $0.id) }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
        llmLogger.info("\(provider.displayName) /models returned \(models.count) entries")
        return models
    }

    func processText(
        _ text: String,
        options: LLMProcessingOptions,
        provider: LLMProvider,
        apiKey: String,
        model: String
    ) async throws -> String {
        guard let systemPrompt = Self.buildSystemPrompt(for: options) else { return text }
        guard !apiKey.isEmpty else { throw APIError.missingKey }
        guard !model.isEmpty else { throw APIError.missingModel }

        var request = URLRequest(url: provider.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        if provider == .openRouter {
            request.setValue("https://github.com/Vocallabsai/vocalflow", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("VocalFlow", forHTTPHeaderField: "X-Title")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text]
            ],
            "temperature": 0
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            llmLogger.error("Failed to encode chat completion request body")
            throw APIError.encoding
        }
        request.httpBody = httpBody

        return try await sendChatCompletion(request: request, provider: provider, allowRetry: true)
    }

    /// Pure prompt assembly. Extracted as `static` so it's deterministic given options
    /// and unit-testable without spinning up a real network. Returns `nil` when no
    /// processing steps are enabled (caller short-circuits to passthrough).
    static func buildSystemPrompt(for options: LLMProcessingOptions) -> String? {
        guard options.hasAnyStep else { return nil }

        var instructions: [String] = []
        var stepNumber = 1

        if let mixType = options.codeMix {
            instructions.append("\(stepNumber). The input is in \(mixType). Transliterate any non-Roman script (such as Devanagari, Tamil, etc.) to Roman script. Keep English words as-is. Do not translate — preserve the original meaning in mixed form.")
            stepNumber += 1
        }
        if options.fixSpelling {
            instructions.append("\(stepNumber). Fix any spelling mistakes. Do not change meaning or structure.")
            stepNumber += 1
        }
        if options.fixGrammar {
            instructions.append("\(stepNumber). Fix any grammar mistakes. Do not change meaning or add content.")
            stepNumber += 1
        }
        if let lang = options.targetLanguage {
            instructions.append("\(stepNumber). Translate the entire text to \(lang). Every word must be in \(lang).")
        }

        let stepsBlock: String? = instructions.isEmpty ? nil :
            "Process the following text by applying these steps in order:\n"
            + instructions.joined(separator: "\n")

        let trimmedCustom = options.customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customBlock: String? = trimmedCustom.isEmpty ? nil : trimmedCustom

        let blocks = [customBlock, stepsBlock, "Return only the final processed text with no explanation."]
            .compactMap { $0 }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Internal helpers

    private func sendChatCompletion(
        request: URLRequest,
        provider: LLMProvider,
        allowRetry: Bool
    ) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await performRequest(request)
        } catch let error as APIError {
            if allowRetry, case .network = error {
                llmLogger.info("Retrying \(provider.displayName) /chat/completions after network error")
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                return try await sendChatCompletion(request: request, provider: provider, allowRetry: false)
            }
            throw error
        }

        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(httpStatus) {
            let bodyStr = String(data: data, encoding: .utf8)
            llmLogger.error("\(provider.displayName) /chat/completions HTTP \(httpStatus): \(bodyStr ?? "<binary>")")
            if allowRetry && (httpStatus == 429 || (500..<600).contains(httpStatus)) {
                llmLogger.info("Retrying \(provider.displayName) /chat/completions after HTTP \(httpStatus)")
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                return try await sendChatCompletion(request: request, provider: provider, allowRetry: false)
            }
            throw APIError.http(status: httpStatus, body: bodyStr)
        }

        guard let root = try? JSONDecoder().decode(LLMChatResponse.self, from: data),
              let result = root.choices?.first?.message?.content,
              !result.isEmpty else {
            let bodyStr = String(data: data, encoding: .utf8)
            llmLogger.error("\(provider.displayName) /chat/completions decode failed: \(bodyStr ?? "<binary>")")
            throw APIError.decoding
        }
        return Self.stripReasoning(result)
    }

    /// Strip reasoning/thinking blocks that some models (DeepSeek R1, Qwen QwQ, etc.) emit
    /// inline in the assistant content. Handles `<think>...</think>`, `<thinking>...</thinking>`,
    /// and `<reasoning>...</reasoning>` tags. Case-insensitive, multiline. If an opening tag
    /// has no closing tag (streamed cut-off), drop everything up to the last seen opener.
    static func stripReasoning(_ text: String) -> String {
        let tags = ["think", "thinking", "reasoning"]
        var output = text
        for tag in tags {
            let pattern = "<\\s*\(tag)\\s*>[\\s\\S]*?<\\s*/\\s*\(tag)\\s*>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(output.startIndex..., in: output)
                output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "")
            }
            // Unbalanced opener: keep only text after the last opening tag.
            let openPattern = "<\\s*\(tag)\\s*>"
            if let openRegex = try? NSRegularExpression(pattern: openPattern, options: [.caseInsensitive]) {
                let range = NSRange(output.startIndex..., in: output)
                if let last = openRegex.matches(in: output, options: [], range: range).last,
                   let swiftRange = Range(last.range, in: output) {
                    output = String(output[swiftRange.upperBound...])
                }
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }
}

// MARK: - Response Models

private struct LLMModelsResponse: Codable {
    let data: [LLMModelEntry]?
}

private struct LLMModelEntry: Codable {
    let id: String
    let name: String?
}

private struct LLMChatResponse: Codable {
    let choices: [LLMChoice]?
}

private struct LLMChoice: Codable {
    let message: LLMMessage?
}

private struct LLMMessage: Codable {
    let content: String?
}
