import Foundation

/// Domain-agnostic error type for HTTP API calls. Used by DeepgramService and LLMService
/// so the UI layer can render a single consistent error message.
enum APIError: Error, Equatable {
    case missingKey
    case missingModel
    case network(String)
    case http(status: Int, body: String?)
    case decoding
    case encoding

    /// Short user-facing message suitable for inline display in Settings or a toast.
    var userMessage: String {
        switch self {
        case .missingKey:
            return "API key is missing."
        case .missingModel:
            return "No model selected."
        case .network(let detail):
            return "Network error: \(detail)"
        case .http(let status, let body):
            switch status {
            case 401, 403:
                return "Unauthorized (\(status)). The API key looks invalid."
            case 404:
                return "Not found (404). The endpoint or model may be wrong."
            case 429:
                return "Rate limited (429). Slow down or upgrade your plan."
            case 500..<600:
                return "Server error (\(status)). Try again shortly."
            default:
                if let snippet = body?.prefix(120), !snippet.isEmpty {
                    return "HTTP \(status): \(snippet)"
                }
                return "HTTP \(status)."
            }
        case .decoding:
            return "Could not parse the response."
        case .encoding:
            return "Could not build the request."
        }
    }
}
