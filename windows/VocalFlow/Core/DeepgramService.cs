using System.Diagnostics;
using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VocalFlow.Core;

/// <summary>
/// Streams 16 kHz mono linear-PCM16 audio to Deepgram over a WebSocket and surfaces interim +
/// final transcripts. Port of the macOS DeepgramService (URLSessionWebSocketTask -> ClientWebSocket).
/// </summary>
public sealed class DeepgramService
{
    private const string ListenUrl = "wss://api.deepgram.com/v1/listen";
    private const string ModelsUrl = "https://api.deepgram.com/v1/models";

    /// <summary>Cap pre-connection buffer at ~10s of 16 kHz mono Int16 audio.</summary>
    private const int MaxBufferedBytes = 16_000 * 2 * 10;

    private static readonly HttpClient Http = new();

    /// <summary>
    /// Fired whenever the live transcript changes (interim or final). The argument is the running
    /// transcript from the start of the current session including the latest interim guess.
    /// May fire on a background thread — the consumer marshals to the UI thread.
    /// </summary>
    public Action<string>? OnPartialTranscript;

    private readonly object _lock = new();
    private ClientWebSocket? _ws;
    private CancellationTokenSource? _cts;
    private readonly SemaphoreSlim _sendLock = new(1, 1);

    private string _accumulatedTranscript = "";
    private string _currentInterim = "";
    private bool _isWaitingForFinal;
    private TaskCompletionSource<string>? _finalTcs;
    private CancellationTokenSource? _timeoutCts;

    private readonly List<byte[]> _pendingFrames = new();
    private bool _isSocketOpen;

    public void Connect(string apiKey, string model, string language)
    {
        lock (_lock)
        {
            _accumulatedTranscript = "";
            _currentInterim = "";
            _isWaitingForFinal = false;
            _finalTcs = null;
            _pendingFrames.Clear();
            _isSocketOpen = false;
        }
        EmitPartial();

        if (string.IsNullOrEmpty(apiKey)) return;

        var uri = new UriBuilder(ListenUrl)
        {
            Query = string.Join('&', new[]
            {
                "encoding=linear16",
                "sample_rate=16000",
                "channels=1",
                $"model={Uri.EscapeDataString(model)}",
                $"language={Uri.EscapeDataString(language)}",
                "punctuate=true",
                "interim_results=true",
            }),
        }.Uri;

        var ws = new ClientWebSocket();
        ws.Options.SetRequestHeader("Authorization", $"Token {apiKey}");
        _ws = ws;
        _cts = new CancellationTokenSource();

        _ = RunAsync(ws, uri, _cts.Token);
    }

    private async Task RunAsync(ClientWebSocket ws, Uri uri, CancellationToken ct)
    {
        try
        {
            await ws.ConnectAsync(uri, ct).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Debug.WriteLine($"[deepgram] connect failed: {e.Message}");
            DeliverAndDisconnect();
            return;
        }

        // Flush any frames captured during the handshake, in order.
        byte[][] frames;
        lock (_lock)
        {
            if (!ReferenceEquals(ws, _ws)) return; // superseded by a newer connection
            frames = _pendingFrames.ToArray();
            _pendingFrames.Clear();
            _isSocketOpen = true;
        }
        foreach (var frame in frames)
            await SendFrameAsync(frame, ct).ConfigureAwait(false);

        await ReceiveLoopAsync(ws, ct).ConfigureAwait(false);
    }

    /// <summary>Send one PCM16 audio frame. Frames captured before the socket opens are buffered.</summary>
    public void SendAudio(byte[] data)
    {
        bool openNow;
        lock (_lock)
        {
            if (_ws == null) return;
            openNow = _isSocketOpen;
            if (!openNow)
            {
                int total = _pendingFrames.Sum(f => f.Length);
                while (total + data.Length > MaxBufferedBytes && _pendingFrames.Count > 0)
                {
                    total -= _pendingFrames[0].Length;
                    _pendingFrames.RemoveAt(0);
                }
                _pendingFrames.Add(data);
            }
        }

        if (openNow)
            _ = SendFrameAsync(data, _cts?.Token ?? CancellationToken.None);
    }

    private async Task SendFrameAsync(byte[] data, CancellationToken ct)
    {
        var ws = _ws;
        if (ws == null || ws.State != WebSocketState.Open) return;
        try
        {
            await _sendLock.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                await ws.SendAsync(new ArraySegment<byte>(data), WebSocketMessageType.Binary, true, ct)
                        .ConfigureAwait(false);
            }
            finally { _sendLock.Release(); }
        }
        catch (Exception e)
        {
            Debug.WriteLine($"[deepgram] send failed: {e.Message}");
        }
    }

    public Task<string> CloseStreamAsync()
    {
        var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_lock)
        {
            _finalTcs = tcs;
            _isWaitingForFinal = true;
        }

        // Empty binary frame = Deepgram's signal to flush and finalize.
        _ = SendFrameAsync(Array.Empty<byte>(), _cts?.Token ?? CancellationToken.None);

        // Safety timeout: deliver what we have after 3 seconds.
        _timeoutCts = new CancellationTokenSource();
        var timeoutToken = _timeoutCts.Token;
        _ = Task.Delay(3000, timeoutToken).ContinueWith(t =>
        {
            if (!t.IsCanceled) DeliverAndDisconnect();
        }, TaskScheduler.Default);

        return tcs.Task;
    }

    /// <summary>Tear down without waiting for a final transcript (e.g. mic capture failed to start).</summary>
    public void Cancel()
    {
        lock (_lock)
        {
            _timeoutCts?.Cancel();
            _timeoutCts = null;
            _finalTcs = null;
            _isWaitingForFinal = false;
            _accumulatedTranscript = "";
            _currentInterim = "";
            _pendingFrames.Clear();
            _isSocketOpen = false;
        }
        Disconnect();
    }

    private async Task ReceiveLoopAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[16 * 1024];
        var sb = new StringBuilder();
        try
        {
            while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
            {
                WebSocketReceiveResult result;
                try
                {
                    result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), ct).ConfigureAwait(false);
                }
                catch (Exception e)
                {
                    Debug.WriteLine($"[deepgram] receive failed: {e.Message}");
                    if (_isWaitingForFinal) DeliverAndDisconnect();
                    return;
                }

                if (result.MessageType == WebSocketMessageType.Close)
                {
                    if (_isWaitingForFinal) DeliverAndDisconnect();
                    return;
                }

                sb.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));
                if (result.EndOfMessage)
                {
                    HandleMessage(sb.ToString());
                    sb.Clear();
                }
            }
        }
        catch (OperationCanceledException) { /* expected on teardown */ }
    }

    private void HandleMessage(string json)
    {
        DeepgramResponse? response;
        try { response = JsonSerializer.Deserialize<DeepgramResponse>(json); }
        catch { return; }
        if (response == null) return;

        string transcript = response.Channel?.Alternatives is { Count: > 0 } alts
            ? alts[0].Transcript ?? ""
            : "";

        if (response.IsFinal == true)
        {
            if (!string.IsNullOrEmpty(transcript))
            {
                lock (_lock)
                {
                    if (_accumulatedTranscript.Length > 0) _accumulatedTranscript += " ";
                    _accumulatedTranscript += transcript;
                }
            }
            lock (_lock) { _currentInterim = ""; }
            EmitPartial();
        }
        else
        {
            lock (_lock) { _currentInterim = transcript; }
            EmitPartial();
        }

        if (_isWaitingForFinal && response.IsFinal == true && response.SpeechFinal == true)
        {
            _timeoutCts?.Cancel();
            DeliverAndDisconnect();
        }
    }

    private void EmitPartial()
    {
        string combined;
        lock (_lock)
        {
            if (_currentInterim.Length == 0) combined = _accumulatedTranscript;
            else if (_accumulatedTranscript.Length == 0) combined = _currentInterim;
            else combined = _accumulatedTranscript + " " + _currentInterim;
        }
        OnPartialTranscript?.Invoke(combined);
    }

    private void DeliverAndDisconnect()
    {
        TaskCompletionSource<string>? tcs;
        string transcript;
        lock (_lock)
        {
            if (!_isWaitingForFinal) return;
            _isWaitingForFinal = false;
            transcript = _accumulatedTranscript;
            tcs = _finalTcs;
            _finalTcs = null;
        }
        tcs?.TrySetResult(transcript);
        Disconnect();
    }

    private void Disconnect()
    {
        var ws = _ws;
        _ws = null;
        try { _cts?.Cancel(); } catch { }
        try { ws?.Abort(); } catch { }
        try { ws?.Dispose(); } catch { }
    }

    public async Task<IReadOnlyList<DeepgramModel>> FetchModelsAsync(string apiKey)
    {
        if (string.IsNullOrEmpty(apiKey)) throw ApiException.MissingKey();

        using var request = new HttpRequestMessage(HttpMethod.Get, ModelsUrl);
        request.Headers.TryAddWithoutValidation("Authorization", $"Token {apiKey}");

        HttpResponseMessage response;
        string body;
        try
        {
            response = await Http.SendAsync(request).ConfigureAwait(false);
            body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            throw ApiException.Network(e.Message);
        }

        if (!response.IsSuccessStatusCode)
            throw ApiException.Http((int)response.StatusCode, body);

        ModelsResponse? root;
        try { root = JsonSerializer.Deserialize<ModelsResponse>(body); }
        catch { throw ApiException.Decoding(); }
        if (root == null) throw ApiException.Decoding();

        var streamingSupport = new Dictionary<string, bool>();
        var displayNames = new Dictionary<string, string>();
        var languageMap = new Dictionary<string, List<string>>();

        foreach (var m in root.Stt ?? new())
        {
            var canonical = m.CanonicalName;
            if (string.IsNullOrEmpty(canonical)) continue;
            streamingSupport[canonical] = (streamingSupport.GetValueOrDefault(canonical)) || (m.Streaming ?? false);
            if (!displayNames.ContainsKey(canonical)) displayNames[canonical] = m.Name ?? canonical;
            var existing = languageMap.GetValueOrDefault(canonical) ?? new();
            foreach (var lang in m.Languages ?? new())
                if (!existing.Contains(lang)) existing.Add(lang);
            languageMap[canonical] = existing;
        }

        var models = streamingSupport
            .Where(kv => kv.Value)
            .Select(kv =>
            {
                var canonical = kv.Key;
                var langs = (languageMap.GetValueOrDefault(canonical) ?? new()).OrderBy(x => x, StringComparer.Ordinal).ToList();
                if (canonical.StartsWith("nova-2") || canonical.StartsWith("nova-3"))
                    langs.Add("multi");
                return new DeepgramModel(canonical, displayNames.GetValueOrDefault(canonical) ?? canonical, langs);
            })
            .OrderBy(m => m.CanonicalName, StringComparer.Ordinal)
            .ToList();

        return models;
    }

    // MARK: - Response DTOs

    private sealed class DeepgramResponse
    {
        [JsonPropertyName("channel")] public DeepgramChannel? Channel { get; set; }
        [JsonPropertyName("is_final")] public bool? IsFinal { get; set; }
        [JsonPropertyName("speech_final")] public bool? SpeechFinal { get; set; }
    }

    private sealed class DeepgramChannel
    {
        [JsonPropertyName("alternatives")] public List<DeepgramAlternative>? Alternatives { get; set; }
    }

    private sealed class DeepgramAlternative
    {
        [JsonPropertyName("transcript")] public string? Transcript { get; set; }
        [JsonPropertyName("confidence")] public double? Confidence { get; set; }
    }

    private sealed class ModelsResponse
    {
        [JsonPropertyName("stt")] public List<ModelEntry>? Stt { get; set; }
        [JsonPropertyName("tts")] public List<ModelEntry>? Tts { get; set; }
    }

    private sealed class ModelEntry
    {
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("canonical_name")] public string? CanonicalName { get; set; }
        [JsonPropertyName("streaming")] public bool? Streaming { get; set; }
        [JsonPropertyName("languages")] public List<string>? Languages { get; set; }
    }
}
