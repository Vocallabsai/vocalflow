import AVFoundation
import AudioToolbox

/// Captures microphone audio and delivers **16 kHz mono Int16 PCM** buffers — the
/// exact format DeepgramService streams (`encoding=linear16&sample_rate=16000&channels=1`).
///
/// iOS version of the macOS `AudioEngine`, hardened for the **keyboard-extension**
/// context, which is far more restrictive than a normal app:
/// - The audio session must stay minimal: record-only category first (a keyboard
///   process may not get speaker/output access, which makes full-duplex configs
///   fail at engine start with 'what' / 2003329396).
/// - Capture tries `AVAudioEngine` first, then falls back to a C-level
///   `AudioQueue` input (works in more restricted contexts, and yields
///   16 kHz Int16 directly — no converter). `activePath` reports which one won.
final class MicCapture {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioFormat) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var audioQueue: AudioQueueRef?
    /// "engine" or "queue" after a successful start — shown in the spike UI.
    private(set) var activePath: String = "none"

    fileprivate let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!

    /// Step-labeled error so the keyboard's status label says exactly which
    /// audio call failed (session configs behave differently inside extensions).
    struct MicCaptureError: LocalizedError {
        let step: String
        let detail: String
        var errorDescription: String? { "\(step) failed: \(detail)" }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()

        // Record-only first: keyboards may not be granted the output side.
        do {
            try session.setCategory(.record, mode: .default)
        } catch {
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        }
        do {
            try session.setActive(true, options: [])
        } catch {
            throw MicCaptureError(step: "Audio session", detail: error.localizedDescription)
        }

        // Path 1: AVAudioEngine input tap.
        do {
            try startEngine()
            activePath = "engine"
            return
        } catch {
            engine.stop()
            // Path 2: AudioQueue input.
            do {
                try startQueue()
                activePath = "queue"
            } catch let queueError {
                let engineDetail = (error as? MicCaptureError)?.detail ?? error.localizedDescription
                throw MicCaptureError(
                    step: "Mic capture",
                    detail: "engine: \(engineDetail); queue: \(queueError.localizedDescription)"
                )
            }
        }
    }

    func stop() {
        if activePath == "engine" {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            audioQueue = nil
        }
        activePath = "none"
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Path 1: AVAudioEngine

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicCaptureError(step: "Input route", detail: "no microphone available to the keyboard")
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer, inputFormat: inputFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicCaptureError(step: "Audio engine", detail: error.localizedDescription)
        }
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

    // MARK: - Path 2: AudioQueue (C API fallback)

    private func startQueue() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var queue: AudioQueueRef?
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let createStatus = AudioQueueNewInput(&asbd, Self.queueCallback, userData, nil, nil, 0, &queue)
        guard createStatus == noErr, let queue else {
            throw MicCaptureError(step: "AudioQueue create", detail: "OSStatus \(createStatus)")
        }

        // 3 × 100 ms buffers (16k Hz × 2 bytes × 0.1 s = 3200 bytes).
        for _ in 0..<3 {
            var bufferRef: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(queue, 3200, &bufferRef) == noErr, let bufferRef {
                AudioQueueEnqueueBuffer(queue, bufferRef, 0, nil)
            }
        }

        let startStatus = AudioQueueStart(queue, nil)
        guard startStatus == noErr else {
            AudioQueueDispose(queue, true)
            throw MicCaptureError(step: "AudioQueue start", detail: "OSStatus \(startStatus)")
        }
        audioQueue = queue
    }

    private static let queueCallback: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
        guard let userData else { return }
        let mic = Unmanaged<MicCapture>.fromOpaque(userData).takeUnretainedValue()

        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        if byteCount >= 2 {
            let frames = AVAudioFrameCount(byteCount / 2)
            if let pcm = AVAudioPCMBuffer(pcmFormat: mic.targetFormat, frameCapacity: frames),
               let channel = pcm.int16ChannelData {
                pcm.frameLength = frames
                memcpy(channel[0], buffer.pointee.mAudioData, byteCount)
                mic.onBuffer?(pcm, mic.targetFormat)
            }
        }
        // Hand the buffer back for reuse (ignore failure during teardown).
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}
