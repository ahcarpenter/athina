@preconcurrency import AVFoundation
import AthinaCore
import Foundation
import OSLog
import Speech

/// Which of SpeechAnalyzer's transcribers serves the Mac's language, and in
/// which locale. SpeechTranscriber is the one Apple built for this; for a
/// language it does not cover, DictationTranscriber serves every language
/// the older on-device SFSpeechRecognizer did, so no language needs that
/// recognizer any more. Neither needs the Speech Recognition permission.
struct AnalyzerLanguage: Equatable, Sendable {
    enum Module: String, Sendable {
        case transcriber = "SpeechTranscriber"
        case dictation = "DictationTranscriber"
    }

    var module: Module
    var locale: Locale

    /// "SpeechTranscriber en_US", as the journal records it.
    var modelName: String { "\(module.rawValue) \(locale.identifier)" }

    /// "English (US)".
    var languageName: String { SpeechLanguage.name(of: locale.identifier) }

    /// The best match for `locale` (`SpeechLocaleChoice`), or nil when
    /// SpeechAnalyzer has none.
    static func resolve(for locale: Locale) async -> AnalyzerLanguage? {
        let preferred = Locale.preferredLanguages.first
        if SpeechTranscriber.isAvailable {
            if let match = SpeechLocaleChoice.best(for: locale, preferredLanguage: preferred, supported: await SpeechTranscriber.supportedLocales) {
                return AnalyzerLanguage(module: .transcriber, locale: match)
            }
        }
        if let match = SpeechLocaleChoice.best(for: locale, preferredLanguage: preferred, supported: await DictationTranscriber.supportedLocales) {
            return AnalyzerLanguage(module: .dictation, locale: match)
        }
        // A language only Apple's own equivalence knows, by script or variant.
        if SpeechTranscriber.isAvailable, let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return AnalyzerLanguage(module: .transcriber, locale: match)
        }
        return await DictationTranscriber.supportedLocale(equivalentTo: locale).map { AnalyzerLanguage(module: .dictation, locale: $0) }
    }

    /// A fresh module for one recording, reporting volatile results so the
    /// toast shows words as they are heard. Without fast results
    /// SpeechTranscriber holds them back until the audio ends, which on a
    /// three-second phrase measured as nothing for three and a half seconds
    /// and then every word at once; with them the toast has the first words
    /// after one. The final result, which is what is matched and asked, is
    /// the same either way.
    func makeModule() -> any SpeechModule {
        switch module {
        case .transcriber:
            SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        case .dictation:
            DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        }
    }

    /// Where macOS stands with this language's assets.
    func assetState() async -> SpeechModelState {
        let installed: [Locale] = switch module {
        case .transcriber: await SpeechTranscriber.installedLocales
        case .dictation: await DictationTranscriber.installedLocales
        }
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return .builtIn }
        switch await AssetInventory.status(forModules: [makeModule()]) {
        case .installed: return .builtIn
        case .downloading: return .downloading(fraction: nil)
        case .supported: return .notDownloaded
        case .unsupported: return .failed(reason: "Apple SpeechAnalyzer cannot hear \(languageName) on this Mac.", canRetry: false)
        @unknown default: return .notDownloaded
        }
    }
}

/// Apple's SpeechAnalyzer, the default recognizer: built into macOS 26 and
/// later, on device, with language assets macOS downloads and shares
/// between apps (`AssetInventory`).
@MainActor
final class SpeechAnalyzerBackend: SpeechBackend {
    let language: AnalyzerLanguage

    init(language: AnalyzerLanguage) {
        self.language = language
    }

    var origin: TranscriptOrigin { .heard(backend: .speechAnalyzer, model: language.modelName) }
    var finalResultTimeout: TimeInterval { 3 }

    func begin(format: AVAudioFormat, report: @escaping @Sendable (SpeechUpdate) -> Void) throws -> any SpeechRecognition {
        AnalyzerRecognition(language: language, inputFormat: format, report: report)
    }
}

/// One recording through SpeechAnalyzer. Audio that arrives before the
/// analyzer has chosen its format is kept and converted once it has, so the
/// first word is never lost to the start-up. The end of the audio finishes
/// the input stream and finalizes the analysis, which ends the results.
private final class AnalyzerRecognition: SpeechRecognition, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.ahcarpenter.athina", category: "voice")

    private let report: @Sendable (SpeechUpdate) -> Void
    private let inputFormat: AVAudioFormat
    private let lock = NSLock()
    private let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: PCMConverter?
    private var analyzer: SpeechAnalyzer?
    private var early: [AVAudioPCMBuffer] = []
    private var audioEnded = false
    private var finalizing = false
    private var cancelled = false
    private var work: Task<Void, Never>?
    private var results: Task<Void, Never>?

    init(language: AnalyzerLanguage, inputFormat: AVAudioFormat, report: @escaping @Sendable (SpeechUpdate) -> Void) {
        self.report = report
        self.inputFormat = inputFormat
        (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let module = language.makeModule()
        work = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run(module: module)
        }
    }

    private func run(module: any SpeechModule) async {
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: inputFormat),
              let converter = PCMConverter(from: inputFormat, to: format)
        else {
            report(.failed("SpeechAnalyzer offered no audio format for this input."))
            return
        }
        let report = report
        let results = Task {
            var settled = ""
            var volatile = ""
            do {
                for try await result in AnalyzerRecognition.texts(of: module) {
                    if result.isFinal {
                        settled += result.text
                        volatile = ""
                    } else {
                        volatile = result.text
                    }
                    report(.partial(settled + volatile))
                }
            } catch is CancellationError {
                return
            } catch {
                AnalyzerRecognition.log.notice("SpeechAnalyzer results ended with \(String(describing: error), privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            let text = (settled.isEmpty ? volatile : settled).trimmingCharacters(in: .whitespacesAndNewlines)
            report(.final(text.isEmpty ? nil : text))
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            results.cancel()
            if !isCancelled { report(.failed("SpeechAnalyzer could not start: \(error.localizedDescription)")) }
            return
        }

        // Conversion happens under the lock, here for the audio kept while
        // starting and in `append` for the rest, so the analyzer hears it in
        // the order it was captured.
        let wasCancelled = lock.withLock {
            self.converter = converter
            self.analyzer = analyzer
            self.results = results
            for buffer in early {
                yield(buffer, through: converter)
            }
            early.removeAll()
            return cancelled
        }
        if wasCancelled {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            return
        }
        await finalizeIfEnded()
    }

    /// Once the audio has ended and the analyzer is running, and only once.
    private func finalizeIfEnded() async {
        let ready: SpeechAnalyzer? = lock.withLock {
            guard audioEnded, !finalizing, !cancelled, let analyzer, let converter else { return nil }
            finalizing = true
            if let rest = converter.flush() {
                continuation.yield(AnalyzerInput(buffer: rest))
            }
            continuation.finish()
            return analyzer
        }
        guard let analyzer = ready else { return }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            AnalyzerRecognition.log.notice("SpeechAnalyzer did not finalize: \(String(describing: error), privacy: .public)")
        }
    }

    /// The text of each result either transcriber reports, and whether it is final.
    private static func texts(of module: any SpeechModule) -> AsyncThrowingStream<(text: String, isFinal: Bool), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let transcriber = module as? SpeechTranscriber {
                        for try await result in transcriber.results {
                            continuation.yield((String(result.text.characters), result.isFinal))
                        }
                    } else if let dictation = module as? DictationTranscriber {
                        for try await result in dictation.results {
                            continuation.yield((String(result.text.characters), result.isFinal))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !audioEnded else { return }
        if let converter {
            yield(buffer, through: converter)
        } else if let copy = AnalyzerRecognition.copy(buffer) {
            // The buffer is the input's to reuse once this returns.
            early.append(copy)
        }
    }

    func endAudio() {
        lock.lock()
        audioEnded = true
        lock.unlock()
        Task.detached(priority: .userInitiated) { [self] in
            await finalizeIfEnded()
        }
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        audioEnded = true
        let analyzer = analyzer
        let results = results
        lock.unlock()
        guard !wasCancelled else { return }
        results?.cancel()
        continuation.finish()
        work?.cancel()
        if let analyzer {
            Task.detached { await analyzer.cancelAndFinishNow() }
        }
    }

    private func yield(_ buffer: AVAudioPCMBuffer, through converter: PCMConverter) {
        if let converted = converter.convert(buffer) {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            if let data = from.mData, let target = to.mData {
                memcpy(target, data, Int(min(from.mDataByteSize, to.mDataByteSize)))
            }
        }
        return copy
    }
}
