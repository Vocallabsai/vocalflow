import AVFoundation

class AudioEngine {
    private var engine: AVAudioEngine?
    private var isCapturing = false

    // Deepgram wants: 16kHz, mono, linear PCM, 16-bit signed integer
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    typealias BufferCallback = (AVAudioPCMBuffer, AVAudioFormat) -> Void

    func startCapture(callback: @escaping BufferCallback) {
        let newEngine = AVAudioEngine()
        self.engine = newEngine
        let inputNode = newEngine.inputNode

        // Must use hardware's native format for tap installation
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else { return }

        let bufferSize: AVAudioFrameCount = 4096

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self, self.isCapturing else { return }
            self.convertAndSend(buffer: buffer, converter: converter, callback: callback)
        }

        do {
            try newEngine.start()
            isCapturing = true
        } catch { }
    }

    private func convertAndSend(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        callback: BufferCallback
    ) {
        let inputFrames = buffer.frameLength
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputFrames) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        var inputConsumed = false
        var conversionError: NSError?

        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if conversionError == nil && outputBuffer.frameLength > 0 {
            callback(outputBuffer, targetFormat)
        }
    }

    func stopCapture() {
        isCapturing = false
        // Order matters: removeTap BEFORE stop to avoid crash
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
