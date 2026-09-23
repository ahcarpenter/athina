@preconcurrency import AVFoundation
import AthinaCore
import Foundation
import OSLog
import whisper

/// OpenAI's Whisper and NVIDIA's Parakeet, both run by whisper.cpp on this
/// Mac's GPU from a model file Athina downloaded and checked
/// (`SpeechModelStore`). Neither streams: the audio so far is transcribed
/// again about every second for the toast's live transcript, so partial
/// results are coarser than SpeechAnalyzer's, and the whole recording is
/// transcribed once more when it ends, which is what matching and follow-ups
/// use. The model is loaded as a recording starts and let go as it ends, so
/// nothing stays in memory between presses.
@MainActor
final class WhisperCppBackend: SpeechBackend {
    let model: SpeechModel
    let file: URL
    /// The Mac's language, which a multilingual Whisper is told to expect.
    let language: Locale

    init(model: SpeechModel, file: URL, language: Locale) {
        self.model = model
        self.file = file
        self.language = language
    }

    var origin: TranscriptOrigin { .heard(backend: model.backend, model: model.id) }
    /// The first recording in a process also compiles whisper.cpp's GPU
    /// kernels when Metal's shader cache no longer holds them, which took
    /// eight seconds on an M2 Max and can take ten or more; otherwise the
    /// model loads in a fraction of a second.
    var finalResultTimeout: TimeInterval { 20 }

    func begin(format: AVAudioFormat, report: @escaping @Sendable (SpeechUpdate) -> Void) throws -> any SpeechRecognition {
        guard let converter = PCMConverter(from: format) else {
            throw ListenFailure.recognizerUnavailable("\(model.fullName) cannot take audio in this format.")
        }
        WhisperCpp.quietLogs()
        return GGMLRecognition(
            model: model, file: file, language: WhisperCpp.language(for: model, speaking: language), converter: converter, report: report
        )
    }
}

/// whisper.cpp's two model families behind one call.
private enum WhisperCpp {
    /// The language Whisper is told to expect: English for an English-only
    /// model, the Mac's language for a multilingual one when Whisper knows it,
    /// and detection otherwise. Parakeet detects the language itself.
    static func language(for model: SpeechModel, speaking language: Locale) -> String? {
        guard model.backend == .whisper else { return nil }
        guard model.multilingual else { return "en" }
        guard let code = language.language.languageCode?.identifier, whisper_lang_id(code) >= 0 else { return "auto" }
        return code
    }

    static let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

    /// whisper.cpp writes every step of loading a model to stderr; only its
    /// errors are worth the log.
    static func quietLogs() {
        _ = installLogHandlers
    }

    private static let installLogHandlers: Void = {
        whisper_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            Logger(subsystem: "com.ahcarpenter.athina", category: "voice").error("whisper.cpp: \(String(cString: text), privacy: .public)")
        }, nil)
        parakeet_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            Logger(subsystem: "com.ahcarpenter.athina", category: "voice").error("whisper.cpp parakeet: \(String(cString: text), privacy: .public)")
        }, nil)
    }()
}

/// A loaded model, used only on its recognition's queue.
private protocol GGMLContext: AnyObject {
    func transcribe(_ samples: [Float]) -> String
}

private final class WhisperContext: GGMLContext {
    private let context: OpaquePointer
    private let language: String?

    init?(path: String, language: String?) {
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let context = whisper_init_from_file_with_params(path, params) else { return nil }
        self.context = context
        self.language = language
    }

    deinit { whisper_free(context) }

    func transcribe(_ samples: [Float]) -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = WhisperCpp.threads
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_context = true
        params.no_timestamps = true
        params.single_segment = true
        params.suppress_blank = true
        let status: Int32 = (language ?? "auto").withCString { language in
            params.language = language
            return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
        }
        guard status == 0 else { return "" }
        return (0..<whisper_full_n_segments(context))
            .compactMap { whisper_full_get_segment_text(context, $0).map { String(cString: $0) } }
            .joined()
    }
}

private final class ParakeetContext: GGMLContext {
    private let context: OpaquePointer

    init?(path: String) {
        guard let context = parakeet_init_from_file_with_params(path, parakeet_context_default_params()) else { return nil }
        self.context = context
    }

    deinit { parakeet_free(context) }

    func transcribe(_ samples: [Float]) -> String {
        var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        params.n_threads = WhisperCpp.threads
        let status = samples.withUnsafeBufferPointer { parakeet_full(context, params, $0.baseAddress, Int32($0.count)) }
        guard status == 0 else { return "" }
        return (0..<parakeet_full_n_segments(context))
            .compactMap { parakeet_full_get_segment_text(context, $0).map { String(cString: $0) } }
            .joined()
    }
}

/// One recording through whisper.cpp. Audio is converted to 16 kHz mono as
/// it arrives and kept; the model loads on a serial queue of its own while
/// the first words are captured, and every transcription runs on that queue,
/// one at a time, since a whisper.cpp context is not safe to share.
private final class GGMLRecognition: SpeechRecognition, @unchecked Sendable {
    /// A partial transcript is made once this much more audio has arrived.
    private static let partialEvery = 16_000

    private let queue = DispatchQueue(label: "com.ahcarpenter.athina.whisper-cpp", qos: .userInitiated)
    private let report: @Sendable (SpeechUpdate) -> Void
    private let converter: PCMConverter
    private let lock = NSLock()
    private var samples: [Float] = []
    private var transcribedCount = 0
    private var busy = false
    private var loaded = false
    private var ended = false
    private var cancelled = false
    /// Touched only on `queue`.
    private var context: GGMLContext?

    init(model: SpeechModel, file: URL, language: String?, converter: PCMConverter, report: @escaping @Sendable (SpeechUpdate) -> Void) {
        self.converter = converter
        self.report = report
        queue.async { [self] in
            guard !isCancelled else { return }
            let path = file.path
            context = model.backend == .whisper ? WhisperContext(path: path, language: language) : ParakeetContext(path: path)
            guard context != nil else {
                report(.failed("\(model.fullName) could not be loaded from \(file.lastPathComponent). Delete it in Settings > General and download it again."))
                cancel()
                return
            }
            lock.lock()
            loaded = true
            lock.unlock()
            transcribePartialIfDue()
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard !ended, !cancelled else { lock.unlock(); return }
        if let converted = converter.convert(buffer) {
            samples += PCMConverter.samples(of: converted)
        }
        lock.unlock()
        transcribePartialIfDue()
    }

    /// A partial transcript of everything so far, when the model is loaded,
    /// nothing else is running, and a second more has arrived since the last.
    private func transcribePartialIfDue() {
        lock.lock()
        guard loaded, !busy, !ended, !cancelled, samples.count - transcribedCount >= GGMLRecognition.partialEvery else {
            lock.unlock()
            return
        }
        busy = true
        let snapshot = samples
        lock.unlock()
        queue.async { [self] in
            let text = context?.transcribe(snapshot) ?? ""
            lock.lock()
            busy = false
            transcribedCount = snapshot.count
            let stillListening = !ended && !cancelled
            lock.unlock()
            if stillListening, !text.isEmpty { report(.partial(text)) }
        }
    }

    func endAudio() {
        lock.lock()
        guard !ended, !cancelled else { lock.unlock(); return }
        ended = true
        if let rest = converter.flush() {
            samples += PCMConverter.samples(of: rest)
        }
        let all = samples
        lock.unlock()
        // Queued behind the model load and any partial still running.
        queue.async { [self] in
            guard !isCancelled else { return }
            let text = (context?.transcribe(all) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            report(.final(text.isEmpty ? nil : text))
            context = nil
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.async { [self] in context = nil }
    }
}
