import AVFoundation
import AthinaCore
import Foundation
import OSLog
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
  /// Audio is captured for this long after the key comes up. People let go
  /// as the last word ends, and the recognizer needs the whole word.
  static let releaseGrace: TimeInterval = 0.7
  /// How long to wait for the recognizer's final result after the audio ends.
  static let finalResultTimeout: TimeInterval = 3

  private static let log = Logger(subsystem: "com.ahcarpenter.athina", category: "voice")

  /// Whether the system recognizer can transcribe the locale on this Mac.
  static func availability(for locale: Locale = .current) -> Availability {
    let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      return .unavailable(reason: "No speech recognizer exists for \(name).")
    }
    guard recognizer.supportsOnDeviceRecognition else {
      return .unavailable(
        reason: "On-device speech recognition is not available for \(name), so talking back is off."
      )
    }
    return .available(locale: name)
  }

  /// What the release grace and the wait for a final result are waited out on.
  private let clock: any AthinaClock
  private(set) var isListening = false
  private var engine: AVAudioEngine?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  /// Counts recordings, so a recognizer callback or a timeout left over
  /// from an earlier one cannot touch the current one.
  private var session = 0
  private var latest = ""
  private var finished = true
  private var finishing = false
  private var partials = 0
  private var waiters: [CheckedContinuation<String?, Never>] = []

  init(clock: any AthinaClock) {
    self.clock = clock
  }

  /// Starts capturing and transcribing. `onPartial` receives the transcript
  /// as it grows, on the main actor.
  func start(onPartial: @escaping @MainActor (String) -> Void) throws {
    guard !isListening else { throw Failure.alreadyListening }
    guard let recognizer = SFSpeechRecognizer(locale: .current),
      recognizer.supportsOnDeviceRecognition
    else {
      throw Failure.unavailable
    }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }

    cancel()
    session += 1
    let session = session
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    request.taskHint = .dictation
    latest = ""
    finished = false
    finishing = false
    partials = 0

    // Both callbacks below run on the framework's own threads, so they are
    // `@Sendable`: a closure written here would otherwise be inferred to
    // be main-actor isolated, and the runtime traps on entry off the main
    // actor. Only plain values cross to the main actor.
    task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failure = error.map { String(describing: $0) }
      Task { @MainActor [weak self] in
        self?.handle(
          session: session,
          text: text,
          isFinal: isFinal,
          failure: failure,
          onPartial: onPartial
        )
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
    guard isListening, !finishing else { return nil }
    finishing = true
    let session = session
    // Keep capturing for a moment: the tail of the last word is still
    // being said when the key comes up.
    try? await clock.sleep(for: .seconds(SpeechListener.releaseGrace))
    guard session == self.session else { return nil }
    stopAudio()
    request?.endAudio()
    SpeechListener.log.notice(
      "audio ended after \(self.partials) partial results, \(self.latest.split(separator: " ").count) words so far"
    )
    if finished { return transcript }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
      let clock = clock
      Task { @MainActor [weak self] in
        try? await clock.sleep(for: .seconds(SpeechListener.finalResultTimeout))
        guard let self, self.session == session, !self.finished else { return }
        SpeechListener.log.notice(
          "no final result within \(SpeechListener.finalResultTimeout)s, keeping the latest partial"
        )
        self.complete()
      }
    }
  }

  /// Stops capturing and drops whatever was heard; a `finish` still waiting
  /// on the recognizer returns nil.
  func cancel() {
    stopAudio()
    latest = ""
    complete()
  }

  private var transcript: String? {
    let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private func handle(
    session: Int,
    text: String?,
    isFinal: Bool,
    failure: String?,
    onPartial: @MainActor (String) -> Void
  ) {
    guard session == self.session, !finished else { return }
    if let text {
      partials += 1
      latest = text
      onPartial(text)
    }
    if let failure {
      // The words themselves stay out of the log; their count and the
      // recognizer's error say enough about what went wrong.
      SpeechListener.log.notice(
        "recognizer stopped with \(failure, privacy: .public) after \(self.partials) partial results"
      )
    } else if isFinal {
      SpeechListener.log.notice(
        "final result after \(self.partials) partial results, \(self.latest.split(separator: " ").count) words"
      )
    }
    if isFinal || failure != nil {
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

  /// Settles the recording's transcript: the recognizer is cancelled so it
  /// reports nothing further, and whoever is waiting gets the words so far.
  private func complete() {
    guard !finished else { return }
    finished = true
    task?.cancel()
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
