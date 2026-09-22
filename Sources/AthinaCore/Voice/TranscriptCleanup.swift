import Foundation

/// Tidies what a recognizer returns before it is shown or matched. Whisper
/// marks sounds that are not speech in brackets or parentheses, such as
/// "[BLANK_AUDIO]" or "(keyboard clicking)", and pads its text with spaces;
/// neither is something the person said. Whisper can also answer silence
/// with a stock phrase, but no rule here can tell that from speech, so the
/// words it did return stand and `TranscriptMatcher` reads them as usual.
public enum TranscriptCleanup {
    public static func clean(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "[", "(":
                depth += 1
            case "]", ")":
                depth = max(0, depth - 1)
            default:
                if depth == 0 { result.append(character) }
            }
        }
        return result
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
