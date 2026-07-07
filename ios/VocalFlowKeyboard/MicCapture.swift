import AVFoundation

/// Captures microphone audio and delivers **16 kHz mono Int16 PCM** buffers — the
/// exact format DeepgramService streams (`encoding=linear16&sample_rate=16000&channels=1`).
///
/// iOS version of the macOS `AudioEngine`: it uses `AVAudioSession` (no input-device
/// enumeration/selection, which iOS doesn't expose) and an `AVAudioConverter` to
/// down-sample/mix the hardware input to Deepgram's format.
///
/// ⚠️ This is the spike's whole point: capturing mic audio from inside a **keyboard
/// extension** (Full Access required, tight memory budget). If this proves flaky,
/// that's the signal to reconsider the approach.
final class MicCapture {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioFormat) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // .playAndRecord so a keyboard (which may not "own" audio) can still record;
        // .duckOthers keeps other audio from blasting over the user.
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: [])

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer, inputFormat: inputFormat)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func convertAndEmit(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 {
            onBuffer?(out, targetFormat)
        }
    }
}
