using NAudio.CoreAudioApi;
using NAudio.Wave;
using VocalFlow.Core;

namespace VocalFlow.Services;

/// <summary>
/// Captures microphone audio via WASAPI and converts it to Deepgram's required format:
/// 16 kHz, mono, linear PCM, 16-bit signed little-endian. Mirrors the macOS AudioEngine, which
/// used AVAudioEngine + AVAudioConverter. Resampling is a stateful linear interpolator so it
/// stays continuous across capture callbacks.
/// </summary>
public sealed class AudioEngine
{
    private const int TargetSampleRate = 16000;

    private WasapiCapture? _capture;
    private LinearResampler? _resampler;
    private volatile bool _isCapturing;
    private Action<byte[]>? _callback;

    /// <summary>Lists active audio capture endpoints. The returned Id is the WASAPI endpoint id.</summary>
    public static IReadOnlyList<AudioInputDevice> AvailableInputDevices()
    {
        var list = new List<AudioInputDevice>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                list.Add(new AudioInputDevice(device.ID, device.FriendlyName));
                device.Dispose();
            }
        }
        catch { /* return what we have */ }
        return list;
    }

    /// <summary>
    /// Start capture. <paramref name="callback"/> receives PCM16 mono 16 kHz byte buffers.
    /// Pass a non-empty <paramref name="deviceUid"/> to pin a specific mic; empty = system default.
    /// </summary>
    public void StartCapture(string? deviceUid, Action<byte[]> callback)
    {
        var device = ResolveDevice(deviceUid);
        var capture = new WasapiCapture(device) { ShareMode = AudioClientShareMode.Shared };

        _callback = callback;
        _resampler = new LinearResampler(capture.WaveFormat.SampleRate, TargetSampleRate);
        capture.DataAvailable += OnDataAvailable;
        capture.RecordingStopped += (_, _) =>
        {
            capture.Dispose();
            device.Dispose();
        };

        _capture = capture;
        _isCapturing = true;
        capture.StartRecording();
    }

    private static MMDevice ResolveDevice(string? deviceUid)
    {
        var enumerator = new MMDeviceEnumerator();
        try
        {
            if (!string.IsNullOrEmpty(deviceUid))
            {
                try
                {
                    var dev = enumerator.GetDevice(deviceUid);
                    if (dev != null && dev.State == DeviceState.Active) return dev;
                    dev?.Dispose();
                }
                catch { /* fall through to default */ }
            }
            return enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        }
        finally { enumerator.Dispose(); }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (!_isCapturing || _callback == null || _resampler == null || _capture == null) return;

        var mono = ToMonoFloat(e.Buffer, e.BytesRecorded, _capture.WaveFormat);
        if (mono.Length == 0) return;

        var pcm = _resampler.Process(mono);
        if (pcm.Length > 0) _callback(pcm);
    }

    public void StopCapture()
    {
        _isCapturing = false;
        try { _capture?.StopRecording(); } catch { }
        _capture = null;
        _resampler = null;
        _callback = null;
    }

    /// <summary>Convert an interleaved capture buffer to mono float samples in [-1, 1].</summary>
    private static float[] ToMonoFloat(byte[] buffer, int bytesRecorded, WaveFormat fmt)
    {
        int channels = Math.Max(1, fmt.Channels);
        bool isFloat = fmt.Encoding == WaveFormatEncoding.IeeeFloat ||
                       (fmt.Encoding == WaveFormatEncoding.Extensible && fmt.BitsPerSample == 32);
        int bytesPerSample = fmt.BitsPerSample / 8;
        if (bytesPerSample == 0) return Array.Empty<float>();

        int totalSamples = bytesRecorded / bytesPerSample;
        int frames = totalSamples / channels;
        var mono = new float[frames];

        for (int frame = 0; frame < frames; frame++)
        {
            float sum = 0f;
            for (int ch = 0; ch < channels; ch++)
            {
                int idx = (frame * channels + ch) * bytesPerSample;
                float sample;
                if (isFloat) // 32-bit IEEE float
                {
                    sample = BitConverter.ToSingle(buffer, idx);
                }
                else if (bytesPerSample == 2) // PCM16
                {
                    sample = BitConverter.ToInt16(buffer, idx) / 32768f;
                }
                else if (bytesPerSample == 4) // PCM32
                {
                    sample = BitConverter.ToInt32(buffer, idx) / 2147483648f;
                }
                else if (bytesPerSample == 3) // PCM24
                {
                    int v = (buffer[idx] | (buffer[idx + 1] << 8) | (sbyte)buffer[idx + 2] << 16);
                    sample = v / 8388608f;
                }
                else
                {
                    sample = 0f;
                }
                sum += sample;
            }
            mono[frame] = sum / channels;
        }
        return mono;
    }

    /// <summary>Stateful linear-interpolation resampler (continuous across blocks).</summary>
    private sealed class LinearResampler
    {
        private readonly double _step;   // source samples advanced per output sample
        private double _nextT;           // absolute source coordinate of the next output sample
        private float _prev;             // sample at absolute index (_base - 1)
        private long _base;              // absolute index of the first sample of the current block

        public LinearResampler(int sourceRate, int targetRate)
        {
            _step = (double)sourceRate / targetRate;
        }

        public byte[] Process(float[] s)
        {
            int n = s.Length;
            if (n == 0) return Array.Empty<byte>();

            var outSamples = new List<short>(n + 4);
            while (Math.Floor(_nextT) <= _base + n - 2)
            {
                long i = (long)Math.Floor(_nextT);
                double f = _nextT - i;
                float left = i < _base ? _prev : s[i - _base];
                float right = s[i + 1 - _base];
                float v = left + (right - left) * (float)f;

                int q = (int)Math.Round(v * 32767f);
                if (q > short.MaxValue) q = short.MaxValue;
                else if (q < short.MinValue) q = short.MinValue;
                outSamples.Add((short)q);

                _nextT += _step;
            }

            _prev = s[n - 1];
            _base += n;

            var bytes = new byte[outSamples.Count * 2];
            for (int k = 0; k < outSamples.Count; k++)
            {
                bytes[k * 2] = (byte)(outSamples[k] & 0xFF);
                bytes[k * 2 + 1] = (byte)((outSamples[k] >> 8) & 0xFF);
            }
            return bytes;
        }
    }
}
