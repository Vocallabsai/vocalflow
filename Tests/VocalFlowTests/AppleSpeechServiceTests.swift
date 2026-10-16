import AVFoundation
import XCTest
@testable import VocalFlow

/// Opt-in integration test: needs the on-device speech model, so it only runs when
/// VOCALFLOW_SPEECH_AUDIO points at a spoken-English audio file, e.g.
///   say -o /tmp/probe.aiff "Hello Coley, please meet Whitton tomorrow."
///   VOCALFLOW_SPEECH_AUDIO=/tmp/probe.aiff swift test --filter AppleSpeechServiceTests
final class AppleSpeechServiceTests: XCTestCase {

    func testTranscribesAudioFedLikeTheMicrophone() async throws {
        guard let path = ProcessInfo.processInfo.environment["VOCALFLOW_SPEECH_AUDIO"] else {
            throw XCTSkip("Set VOCALFLOW_SPEECH_AUDIO to run")
        }
        guard #available(macOS 26, *) else { throw XCTSkip("Needs macOS 26") }

        let service = AppleSpeechService()
        service.begin(apiKey: "", model: "", language: "en-GB", keyterms: ["Coley", "Whitton"])
        // Feed everything at once and release immediately — the worst case, where all audio
        // arrives before the model has loaded and must be buffered, not dropped.
        for buffer in try Self.micShapedBuffers(from: URL(fileURLWithPath: path)) {
            service.sendAudioBuffer(buffer, format: buffer.format)
        }
        let text = await service.closeStream()
        print("Transcript: \(text)")
        XCTAssertTrue(text.lowercased().contains("test"), "Got: \(text)")
        XCTAssertTrue(text.lowercased().contains("tomorrow"), "Got: \(text)")
    }

    /// 16 kHz mono Int16 chunks of 4096 frames — what `AudioEngine` hands the pipeline.
    private static func micShapedBuffers(from url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)

        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                   channels: 1, interleaved: true)!
        let converter = AVAudioConverter(from: source.format, to: target)!
        let total = AVAudioFrameCount(Double(source.frameLength) * 16000 / source.format.sampleRate) + 1
        let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: total)!
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }

        var chunks: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < converted.frameLength {
            let count = min(4096, converted.frameLength - offset)
            let chunk = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: count)!
            chunk.frameLength = count
            memcpy(chunk.int16ChannelData![0], converted.int16ChannelData![0] + Int(offset),
                   Int(count) * MemoryLayout<Int16>.size)
            chunks.append(chunk)
            offset += count
        }
        return chunks
    }
}
