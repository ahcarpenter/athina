import AVFoundation
import Foundation
import Speech

/// Captures the microphone while the talk-back key is held and transcribes
/// it with the system speech recognizer, configured to require on-device
/// recognition so no audio ever reaches a server. When the current locale
/// has no on-device recognizer the feature is unavailable rather than
/// falling back.
@MainActor
final class SpeechListener {
    enum Availability: Equatable {
        case available(locale: String)
        case unavailable(reason: String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case unavailable
        case noInput
        case alreadyListening

        var description: String {
            switch self {
            case .unavailable: "on-device speech recognition is not available"
            case .noInput: "no microphone input is available"
            case .alreadyListening: "already listening"
            }
        }
    }

    /// A recording is cut off after this long in case the release is missed.
    static let maxDuration: TimeInterval = 30
    /// How long to wait for the recognizer's final result after the key is released.
    static let finalResultTimeout: TimeInterval = 3

    /// Whether the system recognizer can transcribe the locale on this Mac.
    static func availability(for locale: Locale = .current) -> Availability {
        let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .unavailable(reason: "No speech recognizer exists for \(name).")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .unavailable(reason: "On-device speech recognition is not available for \(name), so talking back is off.")
        }
        return .available(locale: name)
    }

    private(set) var isListening = false
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finished = false
    private var waiters: [CheckedContinuation<String?, Never>] = []

    /// Starts capturing and transcribing. `onPartial` receives the transcript
    /// as it grows, on the main actor.
    func start(onPartial: @escaping @MainActor (String) -> Void) throws {
        guard !isListening else { throw Failure.alreadyListening }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.supportsOnDeviceRecognition else {
            throw Failure.unavailable
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        latest = ""
        finished = false

        // Both callbacks below run on the framework's own threads, so they are
        // `@Sendable`: a closure written here would otherwise be inferred to
        // be main-actor isolated, and the runtime traps on entry off the main
        // actor. Only plain values cross to the main actor.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.handle(text: text, isFinal: isFinal, failed: failed, onPartial: onPartial)
            }
        }
        // The request is appended to from the audio thread only, and read by
        // the recognizer, which is what it is for.
        nonisolated(unsafe) let tapRequest = request
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            tapRequest.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.request = request
        isListening = true
    }

    /// Stops capturing and returns the transcript once the recognizer has
    /// finalized it, or the best partial one after a bounded wait. Nil when
    /// nothing was recognized.
    func finish() async -> String? {
        guard isListening else { return nil }
        stopAudio()
        request?.endAudio()
        if finished { return transcript }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(SpeechListener.finalResultTimeout))
                self?.complete()
            }
        }
    }

    /// Stops capturing and drops whatever was heard.
    func cancel() {
        guard isListening else { return }
        stopAudio()
        task?.cancel()
        latest = ""
        complete()
    }

    private var transcript: String? {
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool, onPartial: @MainActor (String) -> Void) {
        if let text {
            latest = text
            onPartial(text)
        }
        if isFinal || failed {
            // An error after the audio ends is how the recognizer reports
            // "nothing more"; the latest partial stands as the transcript.
            complete()
        }
    }

    private func stopAudio() {
        isListening = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        task = nil
        request = nil
        let result = transcript
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }
}
