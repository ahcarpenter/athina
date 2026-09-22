@preconcurrency import AVFoundation
import AthinaCore
import Foundation
import OSLog

/// Captures one recording while the talk-back key is held and has the chosen
/// recognizer transcribe it. Every recognizer (`SpeechBackend`) runs on this
/// Mac and none sends audio anywhere; the listener drives each one the same
/// way, so the key, the cutoff, the release grace, and the rule that a
/// recording is its own session hold for all of them. A recognizer that
/// cannot run is reported before the listener is started
/// (`SpeechAvailability`), and talking back stays off rather than falling
/// back to another.
@MainActor
final class SpeechListener {
    /// What a recording came to once the audio ended.
    struct Heard: Equatable {
        /// The transcript, nil when nothing was recognized.
        var text: String?
        /// Why the recognizer stopped early, when it did.
        var failure: String?
        /// Which recognizer heard it.
        var origin: TranscriptOrigin
    }

    /// A recording is cut off after this long in case the release is missed.
    static let maxDuration: TimeInterval = 30
    /// Audio is captured for this long after the key comes up. People let go
    /// as the last word ends, and the recognizer needs the whole word.
    static let releaseGrace: TimeInterval = 0.7

    private static let log = Logger(subsystem: "com.ahcarpenter.athina", category: "voice")

    /// What the release grace and the wait for a final result are waited out on.
    private let clock: any AthinaClock
    private(set) var isListening = false
    private var input: (any AudioInput)?
    private var recognition: (any SpeechRecognition)?
    private var finalResultTimeout: TimeInterval = 3
    private(set) var origin: TranscriptOrigin?
    /// Counts recordings, so a recognizer's report or a timeout left over
    /// from an earlier one cannot touch the current one.
    private var session = 0
    private var latest = ""
    private var failure: String?
    private var finished = true
    private var finishing = false
    private var partials = 0
    private var waiters: [CheckedContinuation<Heard?, Never>] = []

    init(clock: any AthinaClock) {
        self.clock = clock
    }

    /// Starts capturing from `input` and transcribing with `backend`.
    /// `onPartial` receives the transcript as it grows, and `onInputEnded`
    /// is told when the input runs out by itself (a file at its end), both on
    /// the main actor and only for this recording.
    func start(
        backend: any SpeechBackend,
        input: any AudioInput,
        onPartial: @escaping @MainActor (String) -> Void,
        onInputEnded: @escaping @MainActor () -> Void = {}
    ) throws {
        guard !isListening else { throw ListenFailure.alreadyListening }
        let format = try input.prepare()
        cancel()
        session += 1
        let session = session
        latest = ""
        failure = nil
        finished = false
        finishing = false
        partials = 0
        origin = backend.origin
        finalResultTimeout = backend.finalResultTimeout

        // Reports and the end of the input arrive on the recognizer's and the
        // input's own threads; only plain values cross to the main actor, and
        // each carries the session it belongs to.
        let recognition: any SpeechRecognition
        do {
            recognition = try backend.begin(format: format) { @Sendable [weak self] update in
                Task { @MainActor [weak self] in
                    self?.handle(update, session: session, onPartial: onPartial)
                }
            }
        } catch {
            input.stop()
            finished = true
            throw error
        }
        do {
            try input.start(deliver: { @Sendable buffer in
                recognition.append(buffer)
            }, ended: { @Sendable [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.session == session, self.isListening else { return }
                    onInputEnded()
                }
            })
        } catch {
            recognition.cancel()
            input.stop()
            finished = true
            throw error
        }
        self.input = input
        self.recognition = recognition
        isListening = true
    }

    /// Stops capturing and returns what was heard once the recognizer has
    /// settled on it, or the best partial transcript after a bounded wait.
    /// Nil when the recording was cancelled meanwhile.
    func finish() async -> Heard? {
        guard isListening, !finishing, let origin else { return nil }
        finishing = true
        let session = session
        // Keep capturing for a moment: the tail of the last word is still
        // being said when the key comes up.
        try? await clock.sleep(for: .seconds(SpeechListener.releaseGrace))
        guard session == self.session else { return nil }
        stopInput()
        recognition?.endAudio()
        SpeechListener.log.notice("audio ended after \(self.partials) partial results, \(self.latest.split(separator: " ").count) words so far")
        if finished { return heard(origin) }
        let timeout = finalResultTimeout
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            let clock = clock
            Task { @MainActor [weak self] in
                try? await clock.sleep(for: .seconds(timeout))
                guard let self, self.session == session, !self.finished else { return }
                SpeechListener.log.notice("no final result within \(timeout)s, keeping the latest partial")
                self.complete()
            }
        }
    }

    /// Stops capturing and drops whatever was heard; a `finish` still waiting
    /// on the recognizer returns nil.
    func cancel() {
        stopInput()
        latest = ""
        failure = nil
        let pending = waiters
        waiters.removeAll()
        settle()
        for waiter in pending {
            waiter.resume(returning: nil)
        }
    }

    private func heard(_ origin: TranscriptOrigin) -> Heard {
        let text = TranscriptCleanup.clean(latest)
        return Heard(text: text.isEmpty ? nil : text, failure: failure, origin: origin)
    }

    private func handle(_ update: SpeechUpdate, session: Int, onPartial: @MainActor (String) -> Void) {
        guard session == self.session, !finished else { return }
        switch update {
        case .partial(let text):
            partials += 1
            latest = text
            onPartial(TranscriptCleanup.clean(text))
        case .final(let text):
            if let text { latest = text }
            // The words themselves stay out of the log; their count says
            // enough about what happened.
            SpeechListener.log.notice("final result after \(self.partials) partial results, \(self.latest.split(separator: " ").count) words")
            complete()
        case .failed(let reason):
            SpeechListener.log.notice("recognizer stopped with \(reason, privacy: .public) after \(self.partials) partial results")
            failure = reason
            complete()
        }
    }

    private func stopInput() {
        isListening = false
        input?.stop()
        input = nil
    }

    /// Settles the recording: whoever is waiting gets what was heard so far.
    private func complete() {
        guard !finished, let origin else { return }
        let result = heard(origin)
        let pending = waiters
        waiters.removeAll()
        settle()
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    /// The recognizer is cancelled so it reports nothing further and lets go
    /// of its model, whether it finished or the wait for it ran out.
    private func settle() {
        finished = true
        recognition?.cancel()
        recognition = nil
    }
}
