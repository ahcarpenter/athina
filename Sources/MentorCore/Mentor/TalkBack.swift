import Foundation

/// Reads a push-to-talk transcript as one of the toast's answers, a request
/// to close it, or a question for the mentor tier.
///
/// Matching is whole-utterance: after lowercasing, dropping punctuation, and
/// trimming filler words such as "please" from the ends, the rest must equal
/// a known phrase. "Tell me more about the flag" is therefore a question,
/// not the Tell me more answer, which is what the user meant.
public enum TranscriptMatcher {
    public enum Match: Equatable, Sendable {
        /// The utterance is one of the toast's buttons, or "close it".
        case answer(SuggestionFeedback)
        /// Anything else, cleaned up for the follow-up prompt.
        case question(String)
    }

    /// Words that may surround an answer without changing it.
    static let fillers: Set<String> = [
        "please", "mentor", "hey", "ok", "okay", "thanks", "thank", "you", "um", "uh", "so", "just", "yeah", "right", "now",
    ]

    /// Fillers that make sense on the left of an answer only ("now" would
    /// eat the end of "not now").
    static let leadingOnlyFillers: Set<String> = ["now"]

    static let phrases: [(SuggestionFeedback, [String])] = [
        (.tellMeMore, [
            "tell me more", "more", "say more", "go on", "expand", "elaborate", "explain", "explain that", "explain more",
            "show me more", "more details", "tell me more about this", "tell me more about that", "tell me more about it",
            "more about that", "more about this", "tell me",
        ]),
        (.notNow, [
            "not now", "no", "nope", "later", "not right now", "maybe later", "remind me later", "not at the moment",
            "snooze", "snooze it", "not today", "some other time", "another time", "leave it", "skip", "skip it",
            "skip this", "not this time", "no not now",
        ]),
        (.never, [
            "never", "never for this", "never for this one", "never for this app", "never again", "never show this",
            "never show this again", "never show me this again", "do not show this again", "don't show this again",
            "stop suggesting this", "stop suggesting that", "stop this", "never for these", "never do this",
        ]),
        (.dismissed, [
            "never mind", "nevermind", "forget it", "close", "close it", "close this", "dismiss", "dismiss it", "go away",
            "got it", "understood", "done",
        ]),
    ]

    /// Nil when nothing usable was heard.
    public static func match(_ transcript: String) -> Match? {
        let words = normalized(transcript)
        guard !words.isEmpty else { return nil }
        let core = trimmed(words)
        guard !core.isEmpty else { return nil }
        let phrase = core.joined(separator: " ")
        for (feedback, forms) in phrases where forms.contains(phrase) {
            return .answer(feedback)
        }
        return .question(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Lowercase words with punctuation removed, apostrophes kept.
    static func normalized(_ text: String) -> [String] {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        var scalars = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                scalars.append(scalar)
            } else {
                scalars.append(" ")
            }
        }
        return String(scalars).split(separator: " ").map(String.init)
    }

    /// Drops filler words from both ends, never from the middle.
    static func trimmed(_ words: [String]) -> [String] {
        var result = words[...]
        while let first = result.first, fillers.contains(first) {
            result = result.dropFirst()
        }
        while let last = result.last, fillers.contains(last), !leadingOnlyFillers.contains(last) {
            result = result.dropLast()
        }
        return Array(result)
    }
}

/// What push-to-talk is doing, shown in the toast.
public enum TalkBackState: Equatable, Sendable {
    case idle
    /// The key is held; the partial transcript grows as the user speaks.
    case listening(partial: String)
    /// The key was released and the question is with the mentor model.
    case thinking(question: String)

    /// True while the user is talking back: the key is held, or the
    /// transcript or the answer is in progress. The toast then stays visible
    /// whatever else happens: it is not dismissed by a click elsewhere, does
    /// not expire, and is kept in front.
    public var keepsToastUp: Bool {
        switch self {
        case .idle: false
        case .listening, .thinking: true
        }
    }
}

/// One thing the user said about a suggestion while holding the talk-back
/// key, and what the mentor tier answered. The question is the transcript,
/// stored here and nowhere else off this Mac except in the one follow-up
/// call that carried it.
public struct FollowUp: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64
    public var suggestionID: Int64
    public var timestamp: Date
    public var question: String
    /// Nil when the call did not produce one; `error` then says why.
    public var answer: String?
    public var error: String?
    public var model: String
    public var promptVersion: Int
    public var spoken: Bool

    public init(
        id: Int64 = 0,
        suggestionID: Int64,
        timestamp: Date,
        question: String,
        answer: String? = nil,
        error: String? = nil,
        model: String,
        promptVersion: Int,
        spoken: Bool = false
    ) {
        self.id = id
        self.suggestionID = suggestionID
        self.timestamp = timestamp
        self.question = question
        self.answer = answer
        self.error = error
        self.model = model
        self.promptVersion = promptVersion
        self.spoken = spoken
    }
}

/// Whether anything may be spoken aloud right now. Speech follows the
/// sensing mode: nothing is said while paused, idle, on an excluded app,
/// waiting for permissions, or stopped.
public enum SpeechGate {
    public static func maySpeak(mode: SensingMode) -> Bool {
        mode.isActive
    }

    /// Whether a delivered suggestion or answer is read out without being asked.
    public static func speaksAutomatically(settings: MentorSettings, mode: SensingMode) -> Bool {
        settings.speakSuggestions && maySpeak(mode: mode)
    }
}
