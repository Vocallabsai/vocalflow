namespace VocalFlow.Core;

/// <summary>
/// Domain-agnostic error for HTTP API calls. Used by DeepgramService and LlmService so the
/// UI can render a single consistent message. Mirrors the macOS APIError enum.
/// </summary>
public sealed class ApiException : Exception
{
    public enum Kind { MissingKey, MissingModel, Network, Http, Decoding, Encoding }

    public Kind ErrorKind { get; }
    public int HttpStatus { get; }
    public string? Body { get; }

    private ApiException(Kind kind, string message, int httpStatus = 0, string? body = null)
        : base(message)
    {
        ErrorKind = kind;
        HttpStatus = httpStatus;
        Body = body;
    }

    public static ApiException MissingKey() => new(Kind.MissingKey, "API key is missing.");
    public static ApiException MissingModel() => new(Kind.MissingModel, "No model selected.");
    public static ApiException Network(string detail) => new(Kind.Network, detail);
    public static ApiException Http(int status, string? body) => new(Kind.Http, $"HTTP {status}", status, body);
    public static ApiException Decoding() => new(Kind.Decoding, "Could not parse the response.");
    public static ApiException Encoding() => new(Kind.Encoding, "Could not build the request.");

    /// <summary>Short user-facing message suitable for inline display or a toast.</summary>
    public string UserMessage
    {
        get
        {
            switch (ErrorKind)
            {
                case Kind.MissingKey: return "API key is missing.";
                case Kind.MissingModel: return "No model selected.";
                case Kind.Network: return $"Network error: {Message}";
                case Kind.Decoding: return "Could not parse the response.";
                case Kind.Encoding: return "Could not build the request.";
                case Kind.Http:
                    switch (HttpStatus)
                    {
                        case 401:
                        case 403:
                            return $"Unauthorized ({HttpStatus}). The API key looks invalid.";
                        case 404:
                            return "Not found (404). The endpoint or model may be wrong.";
                        case 429:
                            return "Rate limited (429). Slow down or upgrade your plan.";
                        default:
                            if (HttpStatus >= 500 && HttpStatus < 600)
                                return $"Server error ({HttpStatus}). Try again shortly.";
                            if (!string.IsNullOrEmpty(Body))
                            {
                                var snippet = Body!.Length > 120 ? Body[..120] : Body;
                                return $"HTTP {HttpStatus}: {snippet}";
                            }
                            return $"HTTP {HttpStatus}.";
                    }
                default: return Message;
            }
        }
    }
}
