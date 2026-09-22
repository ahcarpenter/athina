@preconcurrency import AVFoundation
import Foundation

/// Converts captured audio to the format a recognizer takes: the
/// microphone's (often 48 kHz, one or two channels) or a file's, to 16 kHz
/// mono Float32 for whisper.cpp, or to whatever SpeechAnalyzer asks for.
/// One converter per recording, fed on the audio thread in order.
public final class PCMConverter {
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    /// 16 kHz mono Float32, what whisper.cpp's Whisper and Parakeet take.
    public static let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat = PCMConverter.speechFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// The buffer in the output format; nil when the converter produced
    /// nothing, which it can for a very short buffer while it fills its filter.
    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        run(input: buffer, endOfStream: false)
    }

    /// Whatever the converter still holds once the audio has ended.
    public func flush() -> AVAudioPCMBuffer? {
        run(input: nil, endOfStream: true)
    }

    private func run(input: AVAudioPCMBuffer?, endOfStream: Bool) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        // Room for the converted buffer and for what the resampler's filter
        // holds back, which comes out at the end: about 1,200 frames from
        // 48 kHz to 16 kHz.
        let frames = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + AVAudioFrameCount(outputFormat.sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames) else { return nil }
        nonisolated(unsafe) var pending = input
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if let next = pending {
                pending = nil
                inputStatus.pointee = .haveData
                return next
            }
            inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// The samples of a mono Float32 buffer.
    public static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

/// An audio file read in the short chunks a microphone delivers, which is
/// how a recording on disk is played into the listener (`FileAudioInput` in
/// the app) for the tests, the end-to-end harness, and the debug panel's
/// Speak Audio File action, with no microphone and no permission at all.
public struct AudioFileChunks {
    public let format: AVAudioFormat
    public let duration: TimeInterval
    private let file: AVAudioFile
    private let chunkFrames: AVAudioFrameCount

    public init(url: URL, chunk: TimeInterval = 0.1) throws {
        file = try AVAudioFile(forReading: url)
        format = file.processingFormat
        duration = Double(file.length) / format.sampleRate
        chunkFrames = max(1, AVAudioFrameCount(format.sampleRate * chunk))
    }

    /// The next chunk, nil at the end of the file.
    public func next() throws -> AVAudioPCMBuffer? {
        // Reading at the end throws rather than returning no frames.
        guard file.framePosition < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
        else { return nil }
        try file.read(into: buffer, frameCount: min(chunkFrames, AVAudioFrameCount(file.length - file.framePosition)))
        return buffer.frameLength > 0 ? buffer : nil
    }

    /// The seconds one chunk holds.
    public var chunkDuration: TimeInterval { Double(chunkFrames) / format.sampleRate }

    /// The whole file in the recognizer format, for a test.
    public static func speechSamples(of url: URL) throws -> [Float] {
        let chunks = try AudioFileChunks(url: url)
        guard let converter = PCMConverter(from: chunks.format) else { return [] }
        var samples: [Float] = []
        while let chunk = try chunks.next() {
            if let converted = converter.convert(chunk) { samples += PCMConverter.samples(of: converted) }
        }
        if let rest = converter.flush() { samples += PCMConverter.samples(of: rest) }
        return samples
    }
}
