import AVFoundation
import Foundation

/// Reads text aloud with the system's speech synthesis and its default voice.
/// Synthesis runs on this Mac; no audio or text goes anywhere else.
@MainActor
final class SpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    /// Called on every start and stop with whether speech is in progress.
    var onSpeakingChange: ((Bool) -> Void)?

    private(set) var isSpeaking = false {
        didSet {
            if isSpeaking != oldValue { onSpeakingChange?(isSpeaking) }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Stops anything in progress and speaks the parts in order, with a short
    /// pause between them.
    func speak(_ parts: [String]) {
        stop()
        let texts = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return }
        for (index, text) in texts.enumerated() {
            let utterance = AVSpeechUtterance(string: text)
            // A nil voice is the system default voice from Spoken Content settings.
            utterance.voice = nil
            utterance.prefersAssistiveTechnologySettings = false
            utterance.postUtteranceDelay = index < texts.count - 1 ? 0.35 : 0
            synthesizer.speak(utterance)
        }
        isSpeaking = true
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    private func utteranceEnded() {
        if !synthesizer.isSpeaking {
            isSpeaking = false
        }
    }
}
