import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: String   // AVCaptureDevice.uniqueID — also the Core Audio device UID
    let name: String
}

enum AudioEngineError: Error, LocalizedError {
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .converterUnavailable: return "Audio converter unavailable."
        }
    }
}

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

    /// Lists available audio input devices. Pass any returned `id` to
    /// `startCapture(deviceUID:)` to pin capture to that device.
    static func availableInputDevices() -> [AudioInputDevice] {
        AVCaptureDevice.devices(for: .audio).map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    /// Resolves an AVCaptureDevice uniqueID (a Core Audio device UID) to the
    /// underlying AudioDeviceID that AudioUnitSetProperty needs.
    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var cfUID: CFString = uid as CFString
        var translation = AudioValueTranslation(
            mInputData: &cfUID,
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &deviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            &size, &translation
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    func startCapture(deviceUID: String? = nil, callback: @escaping BufferCallback) throws {
        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode

        // Pin AVAudioEngine's input HAL to the chosen device. Must happen
        // *before* querying outputFormat/installing the tap, since both
        // depend on the live hardware format.
        if let deviceUID, !deviceUID.isEmpty,
           let deviceID = Self.audioDeviceID(forUID: deviceUID),
           let audioUnit = inputNode.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        // Must use hardware's native format for tap installation
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioEngineError.converterUnavailable
        }

        let bufferSize: AVAudioFrameCount = 4096

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self, self.isCapturing else { return }
            self.convertAndSend(buffer: buffer, converter: converter, callback: callback)
        }

        do {
            try newEngine.start()
        } catch {
            // Leave engine unset on failure so stopCapture is a safe no-op.
            inputNode.removeTap(onBus: 0)
            throw error
        }
        self.engine = newEngine
        isCapturing = true
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
