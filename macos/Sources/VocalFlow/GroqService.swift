import Foundation

struct GroqModel: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct GroqProcessingOptions {
    var codeMix: String?        // nil = disabled; value = mixType e.g. "Hinglish"
    var fixSpelling: Bool
    var fixGrammar: Bool
    var targetLanguage: String? // nil = disabled; value = e.g. "French"

    var hasAnyStep: Bool {
        codeMix != nil || fixSpelling || fixGrammar || targetLanguage != nil
    }
}

private let codeMixStyles: Set<String> = [
    "Hinglish", "Tanglish", "Benglish", "Kanglish", "Tenglish",
    "Minglish", "Punglish", "Spanglish", "Franglais", "Portuñol",
    "Chinglish", "Japlish", "Konglish", "Arabizi", "Sheng", "Camfranglais"
]

class GroqService {
    func fetchModels(apiKey: String, completion: @escaping ([GroqModel]) -> Void) {
        guard !apiKey.isEmpty else { completion([]); return }

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil,
                  let root = try? JSONDecoder().decode(GroqModelsResponse.self, from: data) else {
                completion([])
                return
            }
            let models = (root.data ?? [])
                .filter { $0.object == "model" }
                .map { GroqModel(id: $0.id, displayName: $0.id) }
                .sorted { $0.id < $1.id }
            completion(models)
        }.resume()
    }

    func processText(
        _ text: String,
        options: GroqProcessingOptions,
        apiKey: String,
        model: String,
        completion: @escaping (String) -> Void
    ) {
        guard !apiKey.isEmpty, !model.isEmpty, options.hasAnyStep else { completion(text); return }

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
            if codeMixStyles.contains(lang) {
                instructions.append("\(stepNumber). Rewrite the text in \(lang) style: keep English words as-is, and transliterate any non-Roman script (such as Devanagari, Tamil, etc.) to Roman script. Do not translate — preserve the original meaning in mixed form.")
            } else {
                instructions.append("\(stepNumber). Translate the entire text to \(lang). Every word must be in \(lang).")
            }
        }

        let systemPrompt = "Process the following text by applying these steps in order:\n"
            + instructions.joined(separator: "\n")
            + "\nReturn only the final processed text with no explanation."

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text]
            ],
            "temperature": 0
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            completion(text); return
        }
        request.httpBody = httpBody

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil,
                  let root = try? JSONDecoder().decode(GroqChatResponse.self, from: data),
                  let result = root.choices?.first?.message?.content,
                  !result.isEmpty else {
                completion(text)
                return
            }
            completion(result)
        }.resume()
    }
}
// MARK: - Response Models

private struct GroqModelsResponse: Codable {
    let data: [GroqModelEntry]?
}

private struct GroqModelEntry: Codable {
    let id: String
    let object: String?
}

private struct GroqChatResponse: Codable {
    let choices: [GroqChoice]?
}

private struct GroqChoice: Codable {
    let message: GroqMessage?
}

private struct GroqMessage: Codable {
    let content: String?
}
