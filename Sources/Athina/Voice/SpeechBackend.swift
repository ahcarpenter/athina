@preconcurrency import AVFoundation
import AthinaCore
import Foundation

/// What a recognizer reports about one recording, from whatever thread it
/// works on. The listener takes it to the main actor and drops it when the
/// recording it belongs to has ended.
enum SpeechUpdate: Sendable {
    /// The transcript so far. Streaming recognizers report one as each word
    /// settles; chunked ones every second or so of audio, so theirs is coarser.
    case partial(String)
    /// The whole utterance, once the audio has ended; nil when nothing was heard.
    case final(String?)
    /// The recognizer stopped, and why, in a sentence.
    case failed(String)
}

/// One recording's recognition: fed audio as it is captured, told when it
/// ends, and cancelled when the recording is dropped.
protocol SpeechRecognition: AnyObject, Sendable {
    /// Each buffer the input captures, in order, on the input's own thread.
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio is coming: report the final transcript.
    func endAudio()
    /// Drop everything; report nothing more.
    func cancel()
}

/// The seam every recognizer sits behind. `SpeechListener` drives it the same
/// way for all of them, so everything above it, the key, the 30 second
/// cutoff, the release grace, one session per recording, the toast's live
/// transcript, `TranscriptMatcher`, and follow-up questions, is shared.
@MainActor
protocol SpeechBackend: AnyObject {
    /// Which recognizer and model, journaled with each exchange.
    var origin: TranscriptOrigin { get }
    /// How long, in real time, the final transcript may take once the audio
    /// has ended. The latest partial one stands after that.
    var finalResultTimeout: TimeInterval { get }
    /// Starts recognizing audio that arrives in `format`. `report` may be
    /// called from any thread.
    func begin(format: AVAudioFormat, report: @escaping @Sendable (SpeechUpdate) -> Void) throws -> any SpeechRecognition
}

enum ListenFailure: Error, CustomStringConvertible {
    case noInput
    case alreadyListening
    case unreadableFile(String)
    case recognizerUnavailable(String)

    var description: String {
        switch self {
        case .noInput: "no microphone input is available"
        case .alreadyListening: "already listening"
        case .unreadableFile(let reason): "the recording could not be read: \(reason)"
        case .recognizerUnavailable(let reason): reason
        }
    }
}

// MARK: - Audio inputs

/// Where a recording's audio comes from: the microphone while the key is
/// held, or a file played in as if it were.
@MainActor
protocol AudioInput: AnyObject {
    /// The format buffers arrive in, known before the first one does.
    func prepare() throws -> AVAudioFormat
    /// Delivers buffers on the input's own thread until stopped. `ended` is
    /// called, on any thread, when the input runs out by itself, as a file
    /// does at its end.
    func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void, ended: @escaping @Sendable () -> Void) throws
    func stop()
}

/// The microphone, through AVAudioEngine, only between `start` and `stop`.
@MainActor
final class MicrophoneInput: AudioInput {
    private var engine: AVAudioEngine?

    func prepare() throws -> AVAudioFormat {
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenFailure.noInput }
        self.engine = engine
        return format
    }

    func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void, ended: @escaping @Sendable () -> Void) throws {
        guard let engine else { throw ListenFailure.noInput }
        let input = engine.inputNode
        // The tap block runs on the audio thread, so it is `@Sendable`: a
        // closure written here would otherwise be inferred to be main-actor
        // isolated, and the runtime traps on entry off the main actor.
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
            deliver(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

/// A recording on disk played into the listener in 100 ms chunks at the pace
/// it was recorded, on the app's clock, as a microphone would deliver it. It
/// needs no microphone and no permission, which is what lets the tests, the
/// end-to-end harness, and the debug panel's Speak Audio File action put every
/// recognizer through the whole talk-back path on any Mac.
@MainActor
final class FileAudioInput: AudioInput {
    let url: URL
    private let clock: any AthinaClock
    private var chunks: AudioFileChunks?
    private var task: Task<Void, Never>?

    init(url: URL, clock: any AthinaClock) {
        self.url = url
        self.clock = clock
    }

    func prepare() throws -> AVAudioFormat {
        do {
            let chunks = try AudioFileChunks(url: url)
            self.chunks = chunks
            return chunks.format
        } catch {
            throw ListenFailure.unreadableFile(error.localizedDescription)
        }
    }

    func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void, ended: @escaping @Sendable () -> Void) throws {
        guard let chunks else { throw ListenFailure.unreadableFile("it was not opened") }
        nonisolated(unsafe) let source = chunks
        let clock = clock
        task = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled, let buffer = try? source.next() {
                deliver(buffer)
                try? await clock.sleep(for: .seconds(source.chunkDuration))
            }
            if !Task.isCancelled { ended() }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        chunks = nil
    }
}
